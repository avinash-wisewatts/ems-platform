# Docker Services

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (`compose.yaml`)

All five services are defined in the single root `compose.yaml`
(project `ems-platform-prod`), shared unchanged between staging and
production per the "build once, promote the same artifact" principle —
see [17-cicd-and-deployment.md](17-cicd-and-deployment.md).

## timescaledb

- **Image**: `timescale/timescaledb@sha256:289d55704b...` — pinned by
  digest (not a floating tag). Per an in-file comment, this is the exact
  image already verified healthy on staging (PostgreSQL 16.15, TimescaleDB
  extension 2.29.2), pinned deliberately so an upgrade requires a
  repository change, not an incidental `docker pull`.
- **Purpose**: sole database for metadata, telemetry, and analytics.
- **Env**: `.env` (root).
- **Ports**: `127.0.0.1:5432:5432` — host-local only.
- **Volumes**: `${TIMESCALEDB_DATA_PATH:-./postgres/data/pgdata}:/var/lib/postgresql/data`.
- **Healthcheck**: `pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}`, every 20s, 5 retries.
- **restart**: `unless-stopped`.
- **shm_size**: `512m`.

## telegraf

- **Image**: `telegraf:1.36` — pinned.
- **Purpose**: subscribes to the configured MQTT input (see
  `telegraf/config/telegraf.conf`) and writes telemetry into TimescaleDB
  via the `postgres` output plugin. No application logic of its own.
- **Env**: `.env` (root) + `./telegraf/.env`.
- **Volumes**: `./telegraf/config/telegraf.conf` (read-only), `./telegraf/logs`.
- **No healthcheck defined** in `compose.yaml`.
- **restart**: `unless-stopped`.

## grafana

- **Image**: `grafana/grafana-oss:11.6.0` — pinned.
- **Purpose**: dashboard/visualization layer.
- **Env**: `./grafana/.env` + `./grafana/live-stream.env`.
- **Extra environment**: `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=wisewatts-live-datasource`
  (a custom live-telemetry datasource plugin) and
  `EMS_LIVE_TELEMETRY_WS_BASE_URL=ws://live-telemetry:8090` (internal
  Docker-network WebSocket URL to the `live-telemetry` service).
- **depends_on**: `timescaledb` (`condition: service_healthy`).
- **Ports**: `${GRAFANA_BIND_HOST:-127.0.0.1}:3000:3000` — see
  [03-infrastructure.md](03-infrastructure.md) for the "not publicly
  exposed yet" note.
- **Volumes**: `./grafana/data` (app state, writable), `./grafana/provisioning`
  (read-only, Git-managed), `./grafana/dashboards` (read-only, Git-managed
  dashboard JSON), `./grafana/plugins` (writable).
- **Healthcheck**: `wget` against `/api/health`, greps for `"database":"ok"`
  in the response — every 20s, 10 retries, 30s start period.
- **restart**: `unless-stopped`.

## live-telemetry

- **Image**: `${APP_IMAGE:-ems-platform-prod-app:local}` — in
  staging/production this is set to the exact CI-built,
  git-SHA-tagged image (`ghcr.io/<owner>/<repo>-app:<sha>`); the
  in-file `build:` block (`./app`, `app/Dockerfile`) exists only so local
  `docker compose build` still works for development — deploy scripts
  never pass `--build`.
- **Purpose**: dedicated server-side MQTT subscriber providing real-time
  telemetry to Grafana's live-datasource plugin over WebSocket, so browser
  clients and Grafana itself never receive MQTT broker credentials.
- **Env**: `./app/.env` + `./app/live-telemetry.env` (contains the
  server-side-only HiveMQ credentials — see
  [18-environment-management.md](18-environment-management.md)).
- **depends_on**: `timescaledb` (`condition: service_healthy`).
- **Command**: `uvicorn src.live_main:app --host 0.0.0.0 --port 8090`.
- **Ports**: `127.0.0.1:8090:8090`.
- **Healthcheck**: Python one-liner hitting `/health`, expects
  `{"status": "ok"}` — every 20s, 10 retries, 20s start period.
- **restart**: `unless-stopped`.

## admin-portal

- **Image**: identical `${APP_IMAGE:-ems-platform-prod-app:local}` as
  `live-telemetry` — **same built artifact**, different `command:`
  (the compose file's own comment states this explicitly: "Shares the
  exact same built artifact as live-telemetry... one image... is used for
  both services and promoted unchanged from staging to production").
- **Purpose**: tenant/site/gateway/device/asset onboarding and
  commissioning interface — see [13-admin-portal.md](13-admin-portal.md).
- **Env**: `./app/.env`.
- **depends_on**: `timescaledb` AND `grafana` (both `service_healthy`) —
  the only service depending on Grafana being healthy, since admin-portal
  provisions per-tenant Grafana organizations/dashboards.
- **Ports**: `${ADMIN_PORTAL_BIND_HOST:-127.0.0.1}:8080:8080` — kept
  private during development, same reasoning as Grafana above.
- **Volumes**: `./grafana/dashboards:/app/grafana-dashboards:ro` — the
  admin portal reads the same Git-managed dashboard JSON Grafana serves,
  presumably for per-tenant dashboard provisioning (see
  [12-grafana.md](12-grafana.md) and [13-admin-portal.md](13-admin-portal.md)
  for what's confirmed vs. inferred about this mechanism).
- **Healthcheck**: Python one-liner hitting `/health`, expects
  `status: "ok"` AND `database.status: "ok"` — every 20s, 10 retries, 30s
  start period.
- **restart**: `unless-stopped`.

## Service dependency graph

```
timescaledb (healthy)
    ├── grafana (healthy)
    │       └── admin-portal
    ├── live-telemetry
    └── admin-portal
telegraf — independent (no depends_on; writes directly to timescaledb's
           exposed port, not gated by compose-level health dependency)
```
