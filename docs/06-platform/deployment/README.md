# Docker Services and Deployment Topology

Status: PARTIAL · Last reviewed: 2026-08-24
Verification basis: Repository (`compose.yaml`) + Staging (PostgreSQL only)
Summary/architecture view: [../../04-architecture/deployment-architecture.md](../../04-architecture/deployment-architecture.md)

All five services are defined in the single root `compose.yaml` (project
`ems-platform-prod`), shared unchanged between staging and production per
the "build once, promote the same artifact" principle — see
[../../09-release-and-deployment/ci-cd.md](../../09-release-and-deployment/ci-cd.md).

## Service dependency graph

```text
timescaledb (healthy)
    ├── grafana (healthy)
    │       └── admin-portal
    ├── live-telemetry
    └── admin-portal
telegraf — independent (no depends_on; writes directly to timescaledb's
           exposed port, not gated by compose-level health dependency)
```

## timescaledb

- **Image**: `timescale/timescaledb@sha256:289d55704b...` — pinned by
  digest, deliberately, so an upgrade requires a repository change, not an
  incidental `docker pull`. PostgreSQL 16.15, TimescaleDB extension 2.29.2.
- **Ports**: `127.0.0.1:5432:5432` — host-local only.
- **Volumes**: `${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}:/var/lib/postgresql/data`.
  Production's TimescaleDB predates the current deployment pipeline and has
  live data at `./postgres/data` (no `/pgdata` suffix) — intentional
  divergence from staging's default, not drift.
- **Healthcheck**: `pg_isready`, every 20s, 5 retries.

## telegraf

- **Image**: `telegraf:1.36`.
- **Volumes**: `./telegraf/config/telegraf.conf` (read-only), `./telegraf/logs`.
- **No healthcheck defined.**

## grafana

- **Image**: `grafana/grafana-oss:11.6.0`.
- **Extra environment**: `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=wisewatts-live-datasource`,
  `EMS_LIVE_TELEMETRY_WS_BASE_URL=ws://live-telemetry:8090`.
- **depends_on**: `timescaledb` (healthy).
- **Ports**: `${GRAFANA_BIND_HOST:-127.0.0.1}:3000:3000`.
- **Volumes**: `./grafana/data` (writable app state), `./grafana/provisioning`
  and `./grafana/dashboards` (read-only, Git-managed), `./grafana/plugins`
  (writable).
- **Healthcheck**: `wget` against `/api/health`, greps for `"database":"ok"`.

## live-telemetry

- **Image**: `${APP_IMAGE:-ems-platform-prod-app:local}` — in staging/
  production the exact CI-built, git-SHA-tagged image
  (`ghcr.io/<owner>/<repo>-app:<sha>`); the in-file `build:` block exists
  only so local `docker compose build` works — deploy scripts never pass
  `--build`.
- **Env**: `./app/.env` + `./app/live-telemetry.env` (server-side-only
  HiveMQ credentials — see
  [../../09-release-and-deployment/environments.md](../../09-release-and-deployment/environments.md)).
- **Command**: `uvicorn src.live_main:app --host 0.0.0.0 --port 8090`.
- **Ports**: `127.0.0.1:8090:8090`.

## admin-portal

- **Image**: identical `${APP_IMAGE}` as `live-telemetry` — same built
  artifact, different `command:`.
- **depends_on**: `timescaledb` AND `grafana` (both healthy) — the only
  service depending on Grafana, since admin-portal provisions per-tenant
  Grafana organizations/dashboards.
- **Ports**: `${ADMIN_PORTAL_BIND_HOST:-127.0.0.1}:8080:8080`.
- **Volumes**: `./grafana/dashboards:/app/grafana-dashboards:ro`.
- **Healthcheck**: expects `status:"ok"` AND `database.status:"ok"`.

## Networking / exposure

No service publishes on `0.0.0.0` by default — every override requires an
explicit, host-local `.env` setting. **Reverse proxy / public TLS is
explicitly planned, not implemented**: `compose.yaml`'s own comment on the
`grafana` service: "Grafana is not publicly exposed yet. Access it from the
EC2 host or through an SSH tunnel. Caddy and public TLS exposure will be
configured only after authentication and tenant isolation have been
validated."

## What is unknown

Exact hosting provider/instance type/region. Whether a reverse proxy or
TLS termination exists beyond what `compose.yaml` configures. Live
container status, restart counts, resource utilization — no `docker`/SSH
access has been used in any documented verification session, only
PostgreSQL access.
