# Configuration Catalog

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository

Catalog of configuration surfaces and where each is defined. No values are
reproduced here — see [18-environment-management.md](../18-environment-management.md)
for the env-file boundary rationale.

## Compose-level variables (interpolated by `compose.yaml`, root `.env`)

| Variable | Consumed by | Purpose |
|---|---|---|
| `POSTGRES_USER` | timescaledb healthcheck, telegraf | DB role |
| `POSTGRES_DB` | timescaledb healthcheck, telegraf | DB name |
| `TIMESCALEDB_DATA_PATH` | timescaledb volume mount | Data directory path, environment-specific |
| `ADMIN_PORTAL_BIND_HOST` | admin-portal port mapping | Host bind address, defaults `127.0.0.1` |
| `GRAFANA_BIND_HOST` | grafana port mapping | Host bind address, defaults `127.0.0.1` |
| `APP_IMAGE` | live-telemetry, admin-portal image reference | Set by CI/deploy scripts to the exact git-SHA-tagged image; defaults to a local dev tag |

## Service-specific env files (not interpolated by compose, consumed inside containers)

| File | Service(s) | What it configures |
|---|---|---|
| `telegraf/.env` | telegraf | Referenced by `telegraf/config/telegraf.conf` (MQTT input connection). No `.example` template exists in this repo — see [23-known-issues-and-drift.md](../23-known-issues-and-drift.md). |
| `telegraf/config/telegraf.conf` | telegraf | The actual Telegraf plugin configuration (MQTT input, Postgres output) — Git-managed, mounted read-only. |
| `app/.env` | live-telemetry, admin-portal | Shared application config for both services. |
| `app/live-telemetry.env` | live-telemetry only | Server-side-only MQTT/HiveMQ credentials + Grafana stream token. Template: `app/live-telemetry.env.example`. |
| `grafana/.env` | grafana | Grafana-specific config. |
| `grafana/live-stream.env` | grafana | Live-stream/live-telemetry datasource plugin config. |
| `grafana/provisioning/` | grafana | Declarative datasource/dashboard provisioning, Git-managed — see [12-grafana.md](../12-grafana.md). |

## Database-level configuration (not env files — live config tables)

| Object | Purpose |
|---|---|
| `metadata.grafana_organization_map` | Maps `metadata.organizations` to a Grafana `grafana_org_id`, provisioned at runtime — the actual mechanism by which Grafana's datasource becomes tenant-specific. See [12-grafana.md](../12-grafana.md). |
| `config.gateway_connectivity_policy` | Online/offline threshold configuration for gateway connectivity status. |
| `config.telemetry_capture_policies` | Per-site effective telemetry capture interval (e.g. 60s vs. 300s) — directly determines which aggregation tables are populated for a given site; see [11-aggregation.md](../11-aggregation.md). |
| `config.device_operational_policies` | Controlled vocabulary (`STANDALONE`, `ASSET_ASSIGNED`) for `metadata.devices.operational_policy`. |
| `config.asset_device_relationship_types` / `config.asset_device_relationship_category_compatibility` | Controlled vocabulary and compatibility rules for asset-device relationships (e.g. `PRIMARY_METER` requires an `Energy Meter`-category device). |

## CI-time placeholder configuration

`ci.yml`'s `config-validation` job writes non-secret placeholder files for
all six env-file boundaries purely to satisfy Compose's requirement that
`env_file:` targets exist on disk — see
[17-cicd-and-deployment.md](../17-cicd-and-deployment.md).
