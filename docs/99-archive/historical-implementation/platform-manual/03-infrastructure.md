# Infrastructure

Status: PARTIAL
Last verified: 2026-08-24
Verification basis: Repository, Staging (Postgres only)

## Deployment topology — CURRENT

The platform runs as a single Docker Compose stack (`compose.yaml`,
project name `ems-platform-prod`, used unchanged for both staging and
production — see [17-cicd-and-deployment.md](17-cicd-and-deployment.md)).
Five services: `timescaledb`, `telegraf`, `grafana`, `live-telemetry`,
`admin-portal`. Full per-service detail in
[04-docker-services.md](04-docker-services.md).

**Host topology**: not independently verified this session. No SSH or
infrastructure-provider (e.g. EC2 console) access has been established in
any session covered by this manual — only read-only PostgreSQL access
(staging via a local SSH tunnel to `127.0.0.1:15432`, production via a
direct connection). Comments in `compose.yaml` and
`docs/operations/CICD_PIPELINE.md` reference "the EC2 host" for both
staging and production, implying AWS EC2 hosting, but this is **repository
evidence, not independently verified infrastructure inspection** — marked
UNKNOWN pending direct access.

**Networking / exposure — CURRENT, from `compose.yaml`**:
- `timescaledb`: bound to `127.0.0.1:5432` only — not exposed beyond the host.
- `grafana`: bound to `${GRAFANA_BIND_HOST:-127.0.0.1}:3000` — defaults to
  localhost-only; a host may explicitly override to `0.0.0.0` via its own
  untracked root `.env`.
- `live-telemetry`: bound to `127.0.0.1:8090` only.
- `admin-portal`: bound to `${ADMIN_PORTAL_BIND_HOST:-127.0.0.1}:8080` —
  same override pattern as Grafana.
- **Reverse proxy / public TLS: explicitly PLANNED, not implemented.**
  `compose.yaml`'s own comment on the `grafana` service states: "Grafana is
  not publicly exposed yet. Access it from the EC2 host or through an SSH
  tunnel. Caddy and public TLS exposure will be configured only after
  authentication and tenant isolation have been validated." No Caddy (or
  other reverse proxy) configuration exists anywhere in this repository as
  of this verification.

**Persistence — CURRENT, from `compose.yaml`**:
- `timescaledb` data: `${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}`,
  bind-mounted. Per `docs/operations/CICD_PIPELINE.md`, this path is
  deliberately environment-specific: production's TimescaleDB predates the
  current deployment pipeline and has live data at `./postgres/data`
  (no `/pgdata` suffix), while staging uses the default
  `./postgres/data/pgdata`. This is intentional divergence, not drift.
- `grafana` data: `./grafana/data` (Grafana's own application DB/state),
  bind-mounted, alongside read-only mounts for `grafana/provisioning` and
  `grafana/dashboards` (both Git-managed) and a writable `grafana/plugins`
  directory.

**Healthchecks and startup dependencies — CURRENT, from `compose.yaml`**:
see [04-docker-services.md](04-docker-services.md) for the exact command
per service. `grafana` waits on `timescaledb` being healthy;
`live-telemetry` waits on `timescaledb`; `admin-portal` waits on both
`timescaledb` and `grafana` being healthy.

## What is UNKNOWN

- Exact hosting provider/instance type/region for staging and production hosts.
- Whether a reverse proxy or TLS termination exists in front of anything
  beyond what `compose.yaml` itself configures.
- Live container status, restart counts, and resource utilization — this
  manual's live-verification sessions have had PostgreSQL access only, no
  `docker`/SSH access to either host.

## What is PLANNED, not current

- Public TLS / reverse proxy exposure for Grafana and/or admin-portal
  (explicitly deferred per `compose.yaml`'s own comment, pending
  authentication/tenant-isolation validation).
