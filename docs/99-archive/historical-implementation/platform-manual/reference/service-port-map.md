# Service / Port Map

Status: CURRENT
Last verified: 2026-08-24
Verification basis: Repository (`compose.yaml`)

| Service | Host bind | Container port | Notes |
|---|---|---|---|
| timescaledb | `127.0.0.1:5432` | `5432` | Fixed localhost-only, no override variable. |
| telegraf | — | — | No published port; writes outbound to `timescaledb` and inbound-subscribes to MQTT broker. |
| grafana | `${GRAFANA_BIND_HOST:-127.0.0.1}:3000` | `3000` | Override via host's own untracked root `.env`. |
| live-telemetry | `127.0.0.1:8090` | `8090` | Fixed localhost-only. Internal Docker-network URL used by Grafana: `ws://live-telemetry:8090`. |
| admin-portal | `${ADMIN_PORTAL_BIND_HOST:-127.0.0.1}:8080` | `8080` | Override via host's own untracked root `.env`. |

No service in `compose.yaml` publishes a port on `0.0.0.0` by default —
every override requires an explicit, host-local `.env` setting. See
[03-infrastructure.md](../03-infrastructure.md) for the "not publicly
exposed yet" context.
